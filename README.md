# SSH VPN Panel v1.3.4

A colorized, emoji-free English-language terminal panel for managing Dropbear SSH accounts with Stunnel, Squid, and BadVPN UDPGW. This release adds an admin-only Telegram bot, automatic Cloudflare Worker banner polling, per-account outbound traffic estimates, and a server-side speed test.

## Features

- Create, delete, list, enable/disable, extend, and reset SSH account passwords from the terminal panel.
- Account list and traffic screens show outbound usage (GB) and live Dropbear process count per user.
- Automatically registers `/bin/false` in `/etc/shells`, checks Dropbear, and sets a working account password.
- BBR sysctl tuning and status display. The installer reports whether BBR is actually active; activation depends on support in the running kernel.
- Optional distro-packaged `speedtest-cli`, available in menu option 13. The test measures the VPS/server network path, not a specific phone or account. The latest successful result is saved for later viewing in Telegram stats.
- Cloudflare Worker banner polling every **5 seconds** with a systemd timer; Dropbear is restarted only if the downloaded banner content changes.
- Admin-only Telegram bot configurable from menu option **12** using a BotFather token and numeric Telegram admin user ID. Clean, minimal UI supports account creation, details/search, deletion, enabling/disabling, expiry extension, stored bandwidth-limit editing, password reset, expiring-user lists, online/traffic reports (used GB + connected processes), server health, Worker refresh, and speed tests. Bot replies are private-chat-only and admin-ID restricted.
- Per-account outbound byte counters sampled every minute through iptables owner accounting.
- Dropbear SSH ports `143, 444, 666, 5555, 701, 179`; Stunnel `110, 443, 587`; Squid `8080, 8000, 3128`; BadVPN UDPGW `7300`.

## Performance and security notes

- SSH (Dropbear) is TCP + encryption; it will not match WireGuard UDP throughput. This release raises Dropbear receive window to 1 MiB and expands BBR/sysctl buffer tuning for better high-latency performance.
- Panel VPN accounts always use shell `/bin/false`. They cannot open an interactive shell on the server. Disable locks the Linux password (`usermod -L`) and terminates active sessions.

## Important measurement notes

- The server speed test measures the VPS connection to a speed-test endpoint. It cannot report an individual mobile client's current speed.
- Per-user traffic is an **outbound-only estimate** based on packets sent by processes running under each Linux account. Linux does not reliably attribute inbound response bytes to the originating SSH account with this simple accounting method. Counters start after the sampler is installed and are not a full bidirectional quota meter. Do not use them for billing or strict quota enforcement.
- The five-second Worker check produces up to **17,280 HTTPS requests per day** per server. Keep the Worker endpoint lightweight and check your Cloudflare plan's request limits. The content is fetched over HTTPS and capped at 4 KiB.
- Telegram credentials are stored in `/etc/ssh-vpn-panel/config/telegram.env` with root-only permissions. The bot accepts actions only from the configured admin Telegram ID. Never share the bot token or password-reset messages.

## Requirements

- Root access on Ubuntu (any release with working APT sources) or Debian 11, 12, or 13.
- At least 1 GB RAM and 10 GB disk recommended.
- Outbound HTTPS access is needed for Worker polling, Telegram, and speed testing.

The installer does not rewrite APT repositories. Enabled Ubuntu repositories must match the installed OS codename.

## Install or upgrade

```bash
git clone https://github.com/PlanAslii/sstieq.git
cd sstieq
chmod +x install.sh
sudo ./install.sh
```

For an existing installation, extract the complete v1.3.4 release archive and run `sudo ./upgrade.sh`. This safe in-place upgrade does not reset UFW or overwrite the currently applied banner. It also repairs a clearly incomplete prior bot-created account when only `/etc/skel` files remain; it refuses to overwrite a home folder with unexpected data. Automatic GitHub updates can only obtain the new features after the v1.3.4 source has been published to the configured repository.

Open the menu with:

```bash
sudo sshvpn
```

## Menu additions

| Option | Action |
|---:|---|
| 3 | List accounts with used traffic (GB) and online process count |
| 5 | Per-account traffic + live connections |
| 12 | Configure/disable the Telegram admin bot |
| 13 | Run the VPS/server speed test |
| 14 | Enable / Disable account (locks password + kills sessions) |

## Configure Telegram

1. Create a bot with Telegram's BotFather.
2. Find your own numeric Telegram user ID from a trusted method.
3. Run `sshvpn`, select **12**, and enter the bot token and admin ID. The panel validates the token with Telegram before saving it.
4. Open the bot and send `/start`.

All non-admin Telegram updates are ignored. Bot operations can create/delete Linux accounts, so use a dedicated bot token and keep it private. Choose **12** and enter `DISABLE` to stop the service and remove its saved credentials.

The bot's account-creation flow sets a generated password, expiry, device count, optional displayed bandwidth limit, `/bin/false` shell compatibility, and checks Dropbear readiness. If home creation fails, it creates `/home` when missing and retries with an explicit home-directory repair. It will not adopt or alter an unexpected existing home directory. The bandwidth-limit field is stored for display; it is not a live enforcement mechanism. Both the terminal panel and Telegram bot are emoji-free with a clean layout. Disabled accounts are locked with `usermod -L` and sessions are killed so they cannot reach the server.

## Worker banner

Default Worker URL: `https://mute-bar-da37.planasli1.workers.dev/`.

Edit `worker/success-worker.js` and redeploy the Worker to change the login banner. The server checks the saved URL every five seconds and applies changed content automatically; no need to re-enter the URL. The polling timer and traffic sampler are installed as systemd timers. The existing SSH client may show a plain-text login banner; ANSI colors are not reliably rendered by all clients.

## Files and logs

- Database: `/etc/ssh-vpn-panel/db/users.db`
- Worker banner: `/etc/ssh-vpn-panel/config/banner.txt`
- Telegram secret: `/etc/ssh-vpn-panel/config/telegram.env` (root-only)
- Main menu: `/etc/ssh-vpn-panel/scripts/menu.sh`
- Telegram service log: `journalctl -u sshvpn-telegram-bot -f`
- Worker timer status: `systemctl status sshvpn-banner-refresh.timer`
- Traffic sampler log: `/etc/ssh-vpn-panel/logs/traffic-sampler.log`
- Latest successful server speed test: `/etc/ssh-vpn-panel/logs/speedtest-latest.txt`

## License

MIT. See the project repository for license details.
