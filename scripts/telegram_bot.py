#!/usr/bin/env python3
"""Admin-only Telegram control bot for SSH VPN Panel (Python standard library only)."""
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


def read_config():
    values = {}
    try:
        for line in open(CONFIG, encoding="utf-8"):
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
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        result = json.loads(response.read().decode())
    if not result.get("ok"):
        raise RuntimeError(result.get("description", "Telegram API error"))
    return result["result"]


def validate_token(token):
    info = bot_api("getMe", token=token, timeout=10)
    return info.get("username", "bot")


def db_connect():
    import sqlite3
    db = sqlite3.connect(DB, timeout=10)
    db.row_factory = sqlite3.Row
    return db


def esc(value):
    return html.escape(str(value), quote=False)


def send(chat_id, text, keyboard=None):
    payload = {"chat_id": chat_id, "text": text, "parse_mode": "HTML", "disable_web_page_preview": "true"}
    if keyboard:
        payload["reply_markup"] = json.dumps({"inline_keyboard": keyboard}, ensure_ascii=False)
    bot_api("sendMessage", payload, timeout=15)


def ack(callback_id, text=""):
    bot_api("answerCallbackQuery", {"callback_query_id": callback_id, "text": text[:180]}, timeout=15)


def menu(chat_id):
    rows = [
        [{"text": "➕ Create user", "callback_data": "create"}, {"text": "👥 Users", "callback_data": "users"}],
        [{"text": "🗑 Delete user", "callback_data": "delete"}, {"text": "🔑 Reset password", "callback_data": "reset"}],
        [{"text": "📊 Traffic & online", "callback_data": "stats"}, {"text": "🔄 Refresh Worker banner", "callback_data": "worker"}],
        [{"text": "📅 Extend account", "callback_data": "extend"}],
        [{"text": "🚀 Run server speed test", "callback_data": "speedtest"}],
    ]
    send(chat_id, "<b>PlanAsli SSH VPN Panel</b>\nChoose an action:", rows)


def check_admin(sender_id):
    cfg = read_config()
    return str(sender_id) == cfg.get("ADMIN_ID", "")


def connected_for(username):
    try:
        out = subprocess.check_output(["ps", "-u", username, "-o", "comm="], text=True, stderr=subprocess.DEVNULL, timeout=5)
        return sum(1 for item in out.splitlines() if item.strip() == "dropbear")
    except Exception:
        return 0


def user_list():
    with db_connect() as db:
        return db.execute("SELECT username, expire_date, is_active, bandwidth_limit_gb FROM users ORDER BY id").fetchall()


def used_bytes(username):
    with db_connect() as db:
        row = db.execute("SELECT bytes_total FROM user_traffic WHERE username=?", (username,)).fetchone()
        return int(row[0]) if row else 0


def render_users(chat_id):
    rows = user_list()
    if not rows:
        send(chat_id, "No panel accounts found.")
        return
    lines = ["<b>SSH accounts</b>"]
    for row in rows[:60]:
        gb = used_bytes(row["username"]) / (1024 ** 3)
        active = "active" if row["is_active"] else "disabled"
        lines.append(f"• <code>{esc(row['username'])}</code> · {esc(row['expire_date'])} · {active} · {gb:.3f} GB out")
    if len(rows) > 60:
        lines.append(f"…and {len(rows)-60} more")
    send(chat_id, "\n".join(lines))


def stats_text():
    rows = user_list()
    active_users = 0
    total_sessions = 0
    lines = ["<b>Server user activity</b>"]
    for row in rows:
        username = row["username"]
        sessions = connected_for(username)
        total_sessions += sessions
        if sessions:
            active_users += 1
            lines.append(f"• <code>{esc(username)}</code>: {sessions} SSH session(s), {used_bytes(username)/(1024**3):.3f} GB outbound")
    lines.insert(1, f"Users online: <b>{active_users}</b> · SSH processes: <b>{total_sessions}</b>")
    if active_users == 0:
        lines.append("No active Dropbear user processes detected.")
    lines.append("\nTraffic is a best-effort <b>outbound-only</b> estimate for Dropbear account processes; inbound bytes are not attributed.")
    latest = f"{PANEL}/logs/speedtest-latest.txt"
    try:
        with open(latest, encoding="utf-8") as f:
            lines.append("\n<b>Last server speed test</b>\n<code>" + esc(f.read().strip()[:900]) + "</code>")
    except OSError:
        lines.append("\nNo saved server speed test yet.")
    return "\n".join(lines)


def shell_fix():
    if not os.path.exists("/bin/false") or not os.path.exists("/etc/shells"):
        raise RuntimeError("/bin/false or /etc/shells is missing")
    with open("/etc/shells", "r+", encoding="utf-8") as f:
        contents = f.read().splitlines()
        if "/bin/false" not in contents:
            f.write("\n/bin/false\n")


def create_account(username, days, limit, max_devices=1):
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]{0,31}", username):
        raise ValueError("Invalid username. Use 1–32 letters, digits, dot, underscore, or hyphen; start with a letter/underscore.")
    shell_fix()
    with db_connect() as db:
        if db.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone():
            raise ValueError("That username already exists in the panel.")
    if subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        raise ValueError("That Linux username already exists outside the panel.")
    expiry = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
    password = subprocess.check_output(["openssl", "rand", "-hex", "10"], text=True).strip()
    created = subprocess.run(["useradd", "-m", "-s", "/bin/false", "-e", expiry, username], capture_output=True, text=True)
    if created.returncode:
        raise RuntimeError(created.stderr.strip() or "useradd failed")
    try:
        changed = subprocess.run(["chpasswd"], input=f"{username}:{password}\n", text=True, capture_output=True)
        if changed.returncode:
            raise RuntimeError(changed.stderr.strip() or "chpasswd failed")
        with db_connect() as db:
            db.execute("INSERT INTO users(username,password,expire_date,max_devices,bandwidth_limit_gb,is_active,note) VALUES(?,?,?,?,?,1,?)",
                       (username, password, expiry, max_devices, limit, "Created via Telegram"))
            db.execute("INSERT OR IGNORE INTO user_traffic(username,bytes_total,last_counter) VALUES(?,0,0)", (username,))
        started = subprocess.run(["systemctl", "enable", "--now", "dropbear"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        shell = pwd.getpwnam(username).pw_shell
        password_state = subprocess.run(["passwd", "-S", username], capture_output=True, text=True).stdout.split()
        if started.returncode or shell != "/bin/false" or "/bin/false" not in open("/etc/shells", encoding="utf-8").read().splitlines() or len(password_state) < 2 or password_state[1] != "P" or subprocess.run(["systemctl", "is-active", "--quiet", "dropbear"]).returncode:
            raise RuntimeError("Account was created but SSH readiness verification failed")
        subprocess.run(["/usr/bin/python3", f"{PANEL}/scripts/traffic_sampler.py"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except Exception:
        with db_connect() as db:
            db.execute("DELETE FROM users WHERE username=?", (username,))
            db.execute("DELETE FROM user_traffic WHERE username=?", (username,))
        subprocess.run(["/usr/bin/python3", f"{PANEL}/scripts/traffic_sampler.py", "--remove-user", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        subprocess.run(["userdel", "-r", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise
    return password, expiry


def delete_account(username):
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]{0,31}", username):
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
    return True


def reset_password(username):
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]{0,31}", username):
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
    if started.returncode or shell != "/bin/false" or len(state) < 2 or state[1] != "P" or subprocess.run(["systemctl", "is-active", "--quiet", "dropbear"]).returncode:
        raise RuntimeError("Password was changed, but SSH readiness verification failed")
    return password


def update_worker(chat_id):
    result = subprocess.run([f"{PANEL}/scripts/refresh_banner.sh"], capture_output=True, text=True, timeout=25)
    detail = (result.stdout + result.stderr).strip()
    if result.returncode == 0:
        send(chat_id, "✅ Worker banner check completed. The saved default URL was used; Dropbear restarts only if text changed." + ("\n" + esc(detail) if detail else ""))
    else:
        send(chat_id, "⚠️ Worker refresh failed. The existing banner was kept.\n" + esc(detail[-1200:]))


def on_callback(q):
    data = q.get("data", "")
    chat_id = q.get("message", {}).get("chat", {}).get("id")
    sender = q.get("from", {}).get("id")
    if not check_admin(sender):
        ack(q["id"], "Not authorized")
        return
    ack(q["id"])
    if data == "home":
        menu(chat_id)
    elif data == "create":
        PROMPTS[sender] = {"step": "username"}
        send(chat_id, "Send the new <b>username</b> (letters, digits, dot, underscore, hyphen; starts with a letter or underscore).\nThe bot will generate a strong password.")
    elif data == "users":
        render_users(chat_id)
    elif data == "delete":
        rows = user_list()
        if not rows:
            send(chat_id, "No panel accounts found.")
        else:
            keyboard = [[{"text": row["username"], "callback_data": "del:" + row["username"]}] for row in rows[:80]]
            send(chat_id, "Choose an account to delete:", keyboard)
    elif data.startswith("del:"):
        username = data[4:]
        send(chat_id, f"Delete <code>{esc(username)}</code> and its home directory?", [[{"text": "Confirm delete", "callback_data": "confirmdel:" + username}, {"text": "Cancel", "callback_data": "home"}]])
    elif data.startswith("confirmdel:"):
        username = data[len("confirmdel:"):]
        try:
            delete_account(username)
            send(chat_id, f"✅ Account <code>{esc(username)}</code> deleted; SSH sessions stopped.")
        except Exception as exc:
            send(chat_id, "❌ " + esc(exc))
    elif data == "extend":
        rows = user_list()
        if not rows:
            send(chat_id, "No panel accounts found.")
        else:
            keyboard = [[{"text": row["username"], "callback_data": "extendu:" + row["username"]}] for row in rows[:80]]
            send(chat_id, "Choose an account to extend:", keyboard)
    elif data.startswith("extendu:"):
        username = data[len("extendu:"):]
        PROMPTS[sender] = {"step": "extend_days", "username": username}
        send(chat_id, f"How many days should <code>{esc(username)}</code> be extended from today? Send 1–3650.")
    elif data == "reset":
        rows = user_list()
        if not rows:
            send(chat_id, "No panel accounts found.")
        else:
            keyboard = [[{"text": row["username"], "callback_data": "pw:" + row["username"]}] for row in rows[:80]]
            send(chat_id, "Choose an account for a password reset:", keyboard)
    elif data.startswith("pw:"):
        username = data[3:]
        try:
            password = reset_password(username)
            send(chat_id, f"✅ Password reset and SSH readiness auto-fix completed.\nUsername: <code>{esc(username)}</code>\nNew password: <code>{esc(password)}</code>\n\nKeep this message private; delete it after copying.")
        except Exception as exc:
            send(chat_id, "❌ " + esc(exc))
    elif data in ("stats", "online"):
        send(chat_id, stats_text())
    elif data == "worker":
        update_worker(chat_id)
    elif data == "speedtest":
        send(chat_id, "⏳ Running a server-side speed test; this can take up to three minutes. It is not a direct test of the user's phone.")
        try:
            result = subprocess.run([f"{PANEL}/scripts/run_speedtest.sh"], capture_output=True, text=True, timeout=190)
            output = (result.stdout + result.stderr).strip()
            send(chat_id, ("✅ Latest server test:\n<code>" if result.returncode == 0 else "⚠️ Speed test failed:\n<code>") + esc(output[:2500]) + "</code>")
        except Exception as exc:
            send(chat_id, "⚠️ Speed test error: " + esc(exc))
    else:
        send(chat_id, "Unknown action. Use /start.")


def handle_message(message):
    sender = message.get("from", {}).get("id")
    chat_id = message.get("chat", {}).get("id")
    text = (message.get("text") or "").strip()
    if not check_admin(sender):
        return
    if text in ("/start", "/menu", "/help"):
        menu(chat_id)
        return
    if text == "/users":
        render_users(chat_id)
        return
    if text == "/stats" or text == "/online":
        send(chat_id, stats_text())
        return
    if text == "/refresh":
        update_worker(chat_id)
        return
    if text == "/speedtest":
        send(chat_id, "⏳ Running a server-side speed test; this may take up to three minutes.")
        try:
            result = subprocess.run([f"{PANEL}/scripts/run_speedtest.sh"], capture_output=True, text=True, timeout=190)
            output = (result.stdout + result.stderr).strip()
            send(chat_id, ("✅ Latest server test:\n<code>" if result.returncode == 0 else "⚠️ Speed test failed:\n<code>") + esc(output[:2500]) + "</code>")
        except Exception as exc:
            send(chat_id, "⚠️ Speed test error: " + esc(exc))
        return
    if text.startswith("/password "):
        username = text.split(maxsplit=1)[1]
        try:
            password = reset_password(username)
            send(chat_id, f"✅ SSH auto-fix completed.\nUsername: <code>{esc(username)}</code>\nNew password: <code>{esc(password)}</code>")
        except Exception as exc:
            send(chat_id, "❌ " + esc(exc))
        return
    if text.startswith("/delete "):
        username = text.split(maxsplit=1)[1]
        send(chat_id, f"Confirm deletion of <code>{esc(username)}</code>?", [[{"text": "Confirm", "callback_data": "confirmdel:" + username}, {"text": "Cancel", "callback_data": "home"}]])
        return
    state = PROMPTS.get(sender)
    if not state:
        send(chat_id, "Use /start to open the control panel.")
        return
    if state["step"] == "username":
        if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]{0,31}", text):
            send(chat_id, "Invalid name; send a valid username or /cancel.")
            return
        state.update(username=text, step="days")
        send(chat_id, "Account lifetime in days? Send a number from 1 to 3650.")
    elif state["step"] == "days":
        if not text.isdigit() or not 1 <= int(text) <= 3650:
            send(chat_id, "Enter whole days from 1 to 3650.")
            return
        state.update(days=int(text), step="devices")
        send(chat_id, "Maximum concurrent devices? Send a number from 1 to 100.")
    elif state["step"] == "devices":
        if not text.isdigit() or not 1 <= int(text) <= 100:
            send(chat_id, "Enter a whole number from 1 to 100.")
            return
        state.update(max_devices=int(text), step="limit")
        send(chat_id, "Bandwidth limit in GB (0 means unlimited)?")
    elif state["step"] == "limit":
        try:
            limit = float(text)
            if not math.isfinite(limit) or limit < 0 or limit > 100000:
                raise ValueError
        except ValueError:
            send(chat_id, "Enter a non-negative number (0 = unlimited).")
            return
        username, days, max_devices = state["username"], state["days"], state["max_devices"]
        try:
            password, expiry = create_account(username, days, limit, max_devices)
            del PROMPTS[sender]
            send(chat_id, f"✅ <b>Account created and SSH auto-fix verified</b>\nUser: <code>{esc(username)}</code>\nPassword: <code>{esc(password)}</code>\nExpires: {expiry}\nMax devices: {max_devices}\nBandwidth limit: {limit:g} GB\n\nThe `/bin/false` shell compatibility and password setup were applied. Keep credentials private.")
        except Exception as exc:
            PROMPTS.pop(sender, None)
            send(chat_id, "❌ Account creation failed: " + esc(exc))
    elif state["step"] == "extend_days":
        if not text.isdigit() or not 1 <= int(text) <= 3650:
            send(chat_id, "Enter whole days from 1 to 3650.")
            return
        username = state["username"]
        if subprocess.run(["id", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            PROMPTS.pop(sender, None)
            send(chat_id, "❌ Linux account is missing; no expiry change was made.")
            return
        expiry = (datetime.date.today() + datetime.timedelta(days=int(text))).isoformat()
        with db_connect() as db:
            db.execute("UPDATE users SET expire_date=?, is_active=1 WHERE username=?", (expiry, username))
        subprocess.run(["chage", "-E", expiry, username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["usermod", "-U", username], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        PROMPTS.pop(sender, None)
        send(chat_id, f"✅ <code>{esc(username)}</code> extended through {expiry}.")


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
        admin_id = int(admin)
    except ValueError:
        print("ADMIN_ID must be a numeric Telegram user ID", file=sys.stderr)
        return 1
    try:
        info = bot_api("getMe", token=token, timeout=15)
        print(f"PlanAsli Telegram bot @{info.get('username','')} started")
    except Exception as exc:
        print(f"Telegram getMe failed: {exc}", file=sys.stderr)
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
                        msg = update["message"]
                        if check_admin(msg.get("from", {}).get("id")) and (msg.get("text") or "").strip() == "/cancel":
                            PROMPTS.pop(msg["from"]["id"], None)
                            send(msg["chat"]["id"], "Cancelled. Use /start for the menu.")
                        else:
                            handle_message(msg)
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
