#!/bin/sh
set -eu

PREFIX="${PREFIX:-/usr}"
BIN_DIR="$PREFIX/bin"
CRON_FILE="/etc/crontabs/root"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }

for name in telecom-evidence.sh telecom-evidence-daily.sh telecom-evidence-organize.sh telecom-evidence-seal.sh telecom-evidence-verify.sh; do
  rm -f "$BIN_DIR/$name"
done

if [ -f "$CRON_FILE" ]; then
  tmp="/tmp/telecom-evidence-uninstall.$$"
  trap 'rm -f "$tmp"' EXIT INT TERM
  grep -v -F 'telecom-evidence-' "$CRON_FILE" > "$tmp" || true
  cat "$tmp" > "$CRON_FILE"
  /etc/init.d/cron restart 2>/dev/null || true
fi

echo "Programs and their cron lines removed."
echo "Configuration and evidence were preserved: /etc/telecom-evidence*.conf and /root/telecom-evidence*"
