/**
 * Cloudflare Worker — SSH VPN connection banner
 *
 * Deploy this file as a Cloudflare Worker, then paste its URL into
 * SSH VPN Panel > option 6. Edit the text in `banner` below to rebrand
 * the connection message; no server-side code changes are needed.
 *
 * Keep this response as plain text. Many SSH clients show server banners
 * in their connection log and do not render ANSI terminal color codes.
 */
const banner = `
╭──────────────────────────────────────────────────────────╮
│                 ✨  PLANASLI CONNECTED  ✨                │
├──────────────────────────────────────────────────────────┤
│  🔐  SECURE SSH TUNNEL                                   │
│  🟢  STATUS: ONLINE                                      │
│                                                          │
│  Fast, private, and ready to go.                         │
│  Enjoy the connection — powered by PlanAsli.             │
│                                                          │
│  Stay secure. Stay connected.                            │
╰──────────────────────────────────────────────────────────╯
`.trim();

export default {
  async fetch() {
    return new Response(`${banner}\n`, {
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store, max-age=0",
        "X-Content-Type-Options": "nosniff",
      },
    });
  },
};