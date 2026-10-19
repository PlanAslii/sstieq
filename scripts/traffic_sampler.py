#!/usr/bin/env python3
"""Track best-effort per-account outbound bytes for Dropbear user processes."""
import datetime
import os
import pwd
import re
import sqlite3
import subprocess
import sys

PANEL = "/etc/ssh-vpn-panel"
DB = f"{PANEL}/db/users.db"
LOG = f"{PANEL}/logs/traffic-sampler.log"
IPTABLES = "/usr/sbin/iptables" if os.path.exists("/usr/sbin/iptables") else "iptables"


def log(message):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(f"[{datetime.datetime.now().isoformat(timespec='seconds')}] {message}\n")


def run(args, check=False):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True, check=check, timeout=8)


def chain_for(uid):
    return f"SVPNU_{uid}"


def remove_user(username, db):
    try:
        uid = pwd.getpwnam(username).pw_uid
    except KeyError:
        uid = None
    if uid is not None:
        chain = chain_for(uid)
        # Remove only this panel account's exact accounting jump and chain.
        run([IPTABLES, "-D", "OUTPUT", "-m", "owner", "--uid-owner", str(uid), "-j", chain])
        run([IPTABLES, "-F", chain])
        run([IPTABLES, "-X", chain])
    db.execute("DELETE FROM user_traffic WHERE username=?", (username,))
    db.commit()


def sample(db):
    users = db.execute("SELECT username FROM users").fetchall()
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    for (username,) in users:
        if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]{0,31}", username):
            continue
        try:
            uid = pwd.getpwnam(username).pw_uid
        except KeyError:
            continue
        chain = chain_for(uid)
        if run([IPTABLES, "-N", chain]).returncode != 0:
            # Existing chain is expected; ensure it has a counting RETURN rule.
            listing = run([IPTABLES, "-S", chain])
            if listing.returncode != 0:
                log(f"Cannot create/read accounting chain for {username}; iptables owner accounting unavailable")
                continue
        if run([IPTABLES, "-C", chain, "-j", "RETURN"]).returncode != 0:
            if run([IPTABLES, "-A", chain, "-j", "RETURN"]).returncode != 0:
                continue
        jump = [IPTABLES, "-m", "owner", "--uid-owner", str(uid), "-j", chain]
        if run([IPTABLES, "-C", "OUTPUT", *jump]).returncode != 0:
            if run([IPTABLES, "-I", "OUTPUT", "1", *jump]).returncode != 0:
                log(f"Cannot install output counter for {username}")
                continue
        listing = run([IPTABLES, "-nvx", "-L", chain])
        if listing.returncode != 0:
            continue
        counter = None
        for line in listing.stdout.splitlines():
            fields = line.split()
            if len(fields) > 2 and fields[2] == "RETURN" and fields[1].isdigit():
                counter = int(fields[1])
                break
        if counter is None:
            continue
        row = db.execute("SELECT bytes_total, last_counter FROM user_traffic WHERE username=?", (username,)).fetchone()
        if row is None:
            db.execute("INSERT INTO user_traffic(username, bytes_total, last_counter, last_sample) VALUES (?, ?, ?, ?)",
                       (username, 0, counter, now))
        else:
            total, previous = row
            delta = counter - previous if counter >= previous else counter
            db.execute("UPDATE user_traffic SET bytes_total=?, last_counter=?, last_sample=? WHERE username=?",
                       (int(total) + int(delta), counter, now, username))
    db.commit()


def main():
    if os.geteuid() != 0:
        print("Run as root", file=sys.stderr)
        return 1
    if not os.path.exists(DB):
        return 0
    with sqlite3.connect(DB, timeout=10) as db:
        db.execute("CREATE TABLE IF NOT EXISTS user_traffic (username TEXT PRIMARY KEY, bytes_total INTEGER NOT NULL DEFAULT 0, last_counter INTEGER NOT NULL DEFAULT 0, last_sample TEXT)")
        if len(sys.argv) == 3 and sys.argv[1] == "--remove-user":
            remove_user(sys.argv[2], db)
            return 0
        sample(db)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        log(f"Sampler error: {exc}")
        sys.exit(1)
