#!/bin/sh
set -eu

PREFIX="${PREFIX:-/usr}"
ETC_DIR="${ETC_DIR:-/etc}"
BIN_DIR="$PREFIX/bin"
CRON_FILE="/etc/crontabs/root"
SELF_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
ENABLE_CRON=0
[ "${1:-}" = "--enable-cron" ] && ENABLE_CRON=1

[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
[ -r /etc/openwrt_release ] || echo "WARNING: /etc/openwrt_release not found; continuing in compatible mode."

required="date ip curl sha256sum df dd awk sed grep find sort tar"
optional="ifstatus ubus logger speedtest iperf3 tcpdump nft traceroute ping ssh scp"
missing=""
for cmd in $required; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
if [ -n "$missing" ]; then
  echo "ERROR: missing required commands:$missing" >&2
  echo "Install suitable OpenWrt packages with opkg, then rerun. No packages or network settings were changed." >&2
  exit 2
fi

echo "Optional feature check:"
for cmd in $optional; do
  command -v "$cmd" >/dev/null 2>&1 && echo "  OK   $cmd" || echo "  MISS $cmd (related feature will be skipped)"
done

mkdir -p "$BIN_DIR"
for name in telecom-evidence.sh telecom-evidence-daily.sh telecom-evidence-organize.sh telecom-evidence-seal.sh telecom-evidence-verify.sh; do
  cp "$SELF_DIR/$name" "$BIN_DIR/$name"
  chmod 0755 "$BIN_DIR/$name"
done

if [ ! -e "$ETC_DIR/telecom-evidence.conf" ]; then
  cp "$SELF_DIR/telecom-evidence.conf.example" "$ETC_DIR/telecom-evidence.conf"
  chmod 0600 "$ETC_DIR/telecom-evidence.conf"
else
  echo "KEEP existing $ETC_DIR/telecom-evidence.conf"
fi
if [ ! -e "$ETC_DIR/telecom-evidence-organizer.conf" ]; then
  cp "$SELF_DIR/telecom-evidence-organizer.conf.example" "$ETC_DIR/telecom-evidence-organizer.conf"
  chmod 0600 "$ETC_DIR/telecom-evidence-organizer.conf"
else
  echo "KEEP existing $ETC_DIR/telecom-evidence-organizer.conf"
fi

if [ "$ENABLE_CRON" -eq 1 ]; then
  mkdir -p "$(dirname "$CRON_FILE")"
  touch "$CRON_FILE"
  grep -F "$BIN_DIR/telecom-evidence-daily.sh" "$CRON_FILE" >/dev/null 2>&1 || \
    echo "*/5 * * * * $BIN_DIR/telecom-evidence-daily.sh >/dev/null 2>&1" >> "$CRON_FILE"
  grep -F "$BIN_DIR/telecom-evidence-organize.sh" "$CRON_FILE" >/dev/null 2>&1 || \
    echo "*/10 * * * * $BIN_DIR/telecom-evidence-organize.sh >/tmp/telecom-evidence-organizer-cron.log 2>&1" >> "$CRON_FILE"
  /etc/init.d/cron restart 2>/dev/null || true
  echo "Cron enabled (daily collector checks for 20:30 Asia/Shanghai)."
else
  echo "Cron not enabled. Rerun: ./install.sh --enable-cron"
fi

echo "Installed. Edit $ETC_DIR/telecom-evidence.conf, then run: $BIN_DIR/telecom-evidence.sh --check"
echo "No firewall, interface, routing, DNS, proxy, or other network configuration was changed."
