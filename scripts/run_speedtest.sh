#!/bin/bash
# Run and save the latest successful speedtest-cli result for panel/Telegram display.
set -uo pipefail
PANEL_DIR="/etc/ssh-vpn-panel"
LOG_DIR="$PANEL_DIR/logs"
LATEST="$LOG_DIR/speedtest-latest.txt"
mkdir -p "$LOG_DIR"
if ! command -v speedtest-cli >/dev/null 2>&1; then
    echo "speedtest-cli is not installed. Install with: apt-get install -y speedtest-cli" >&2
    exit 127
fi
printf 'Running server-side test; this does not measure a specific client device.\n\n'
if result=$(timeout 180 speedtest-cli --simple 2>&1); then
    temp=$(mktemp "$LOG_DIR/speedtest-latest.XXXXXX")
    {
        printf 'Tested: %s\n' "$(date -Is)"
        printf '%s\n' "$result"
    } > "$temp"
    chmod 0640 "$temp"
    mv -f "$temp" "$LATEST"
    printf '%s\n' "$result"
    exit 0
else
    status=$?
    printf 'Speed test failed (exit %s):\n%s\n' "$status" "$result" >&2
    exit "$status"
fi
